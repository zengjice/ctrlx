import AppKit
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct AgentNotesTests {
    @Test("Notes preserve pasted text, reload, edit in place and stay isolated by pane and Host")
    func persistenceAndIsolation() throws {
        let preferences = PreferencesService.inMemory()
        try withDependencies {
            $0[PreferencesService.self] = preferences
            $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
        } operation: {
            let local = AgentNoteScope(hostID: nil, paneID: UUID())
            let other = AgentNoteScope(hostID: nil, paneID: UUID())
            let remote = AgentNoteScope(hostID: "remote-pair", paneID: local.paneID)
            let text = "  第一行 👩🏽‍💻\n\t<repo:src/main.swift>\n"
            let store = AgentNotesStore()
            let first = try #require(try store.save(text, for: local))
            try store.save("Other Agent", for: other)
            try store.save("Other Host", for: remote)
            let reloaded = AgentNotesStore()
            #expect(reloaded.notes(for: local).first?.text == text)
            #expect(reloaded.notes(for: other).first?.text == "Other Agent")
            #expect(reloaded.notes(for: remote).first?.text == "Other Host")
            try reloaded.save("Updated\n", id: first, for: local)
            #expect(reloaded.notes(for: local).map(\.id) == [first])
            #expect(AgentNotesStore().notes(for: local).first?.text == "Updated\n")
        }
    }

    @Test("Empty notes are skipped; deletion and pane closure persist without clearing other Agents")
    func cleanup() throws {
        let preferences = PreferencesService.inMemory()
        try withDependencies {
            $0[PreferencesService.self] = preferences
            $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
        } operation: {
            let a = AgentNoteScope(hostID: nil, paneID: UUID())
            let b = AgentNoteScope(hostID: nil, paneID: UUID())
            let remote = AgentNoteScope(hostID: "remote", paneID: a.paneID)
            let store = AgentNotesStore()
            #expect(try store.save(" \n\t ", for: a) == nil)
            #expect(preferences.data(AgentNotesStore.storageKey) == nil)
            let id = try #require(try store.save("First", for: a))
            try store.save("Second", for: a)
            try store.save("Keep", for: b)
            try store.save("Remote", for: remote)
            try store.delete(id, for: a)
            #expect(throws: AgentNotesStore.NoteError.self) { try store.save("Stale editor", id: id, for: a) }
            store.reconcile(hostID: nil, livePanes: [b.paneID])
            let reloaded = AgentNotesStore()
            #expect(reloaded.notes(for: a).isEmpty)
            #expect(reloaded.notes(for: b).first?.text == "Keep")
            #expect(reloaded.notes(for: remote).first?.text == "Remote")
            reloaded.reconcile(hostID: "remote", livePanes: [])
            #expect(AgentNotesStore().notes(for: remote).isEmpty)
        }
    }

    @Test("Unreadable or future notes are retained rather than overwritten", arguments: ["{", #"{"version":2,"collections":[]}"#])
    func invalidArchive(text: String) throws {
        let preferences = PreferencesService.inMemory()
        let original = Data(text.utf8)
        preferences.setData(original, AgentNotesStore.storageKey)
        try withDependencies {
            $0[PreferencesService.self] = preferences
            $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
        } operation: {
            let store = AgentNotesStore()
            #expect(store.issue != nil)
            #expect(throws: AgentNotesStore.NoteError.self) {
                try store.save("New", for: .init(hostID: nil, paneID: UUID()))
            }
            #expect(preferences.data(AgentNotesStore.storageKey) == original)
        }
    }

    @Test("Only a confirmed tmux catalog can trigger note cleanup")
    func authoritativeCatalog() async {
        await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                if arguments.contains("list-panes") {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("no server running".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            let service = TmuxService(tmuxPath: "/usr/bin/true")
            let changes = LockIsolated(0)
            service.setPanesChangedHandler { changes.withValue { $0 += 1 } }
            #expect(!service.hasAuthoritativePaneSnapshot)
            #expect(!HostSessionStateSnapshot.isAuthoritative([:], tmux: service))
            await service.refreshPanes()
            #expect(service.hasAuthoritativePaneSnapshot)
            #expect(HostSessionStateSnapshot.isAuthoritative([:], tmux: service))
            await Task.megaYield()
            #expect(changes.value == 1)
            await service.refreshPanes()
            await Task.megaYield()
            #expect(changes.value == 1)
            #expect(!HostSessionStateSnapshot.isAuthoritative(["%1": .init(paneId: "%1")], tmux: service))
            service.configure(tmuxPath: "/nonexistent/ctrlx-tmux", socketPath: nil)
            await service.refreshPanes()
            #expect(!service.hasAuthoritativePaneSnapshot)
            #expect(!HostSessionStateSnapshot.isAuthoritative([:], tmux: service))
        }
    }

    @Test("Remote snapshot callbacks retain notes until their terminal catalog is confirmed", arguments: [nil, false, true] as [Bool?])
    func remoteSnapshot(confirmed: Bool?) async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = preferences
            $0[SecretsService.self] = .inMemory()
            $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
        } operation: {
            let notes = AgentNotesStore()
            let remote = AgentNoteScope(hostID: "remote", paneID: UUID())
            let other = AgentNoteScope(hostID: "other", paneID: remote.paneID)
            let local = AgentNoteScope(hostID: nil, paneID: remote.paneID)
            for scope in [remote, other, local] {
                try notes.save("Keep", for: scope)
            }
            let original = preferences.data(AgentNotesStore.storageKey)
            let manager = try await ViewerConnectionManager()
            let sessions = SessionStore()
            manager.onSessionState = { sessions.handleStateUpdate($0) }
            AppCoordinator.wireAgentNotes(on: manager, into: notes)
            let receive = try #require(manager.onSessionState)
            let state = SessionStateMessage(
                pairId: "remote", paneStates: [:], workspaceIdentity: .init(hostID: UUID(), serverID: nil),
                hasAuthoritativePaneSnapshot: confirmed
            )
            let available = notes.availability(for: remote)
            try receive(JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state)))
            let reloaded = AgentNotesStore()
            #expect(reloaded.notes(for: remote).isEmpty == (confirmed == true))
            #expect(available() == (confirmed != true))
            if confirmed != true {
                #expect(preferences.data(AgentNotesStore.storageKey) == original)
            }
            #expect(reloaded.notes(for: other).first?.text == "Keep")
            #expect(reloaded.notes(for: local).first?.text == "Keep")
            #expect(sessions.sessionSnapshotIDsByHost["remote"] != nil)
        }
    }

    @Test("A confirmed snapshot must include every discovered pane with its current identity")
    func matchingCatalog() async {
        let identity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let line = [
            "%5", "work", "0", "0", "codex", "/tmp", "80", "24", "1", "codex", "layout", "Agent", "1", "", "", "",
            "@1", identity.serverID, identity.sessionID.uuidString, identity.windowID.uuidString, identity.paneID.uuidString, "$1",
        ].joined(separator: String(PaneInfo.fieldSeparator))
        await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                ProcessResult(exitCode: 0, stdout: arguments.contains("list-panes") ? Data(line.utf8) : Data(), stderr: Data())
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/usr/bin/true")
            await tmux.refreshPanes()
            let pane = PaneState(paneId: "%5", workspaceIdentity: identity)
            #expect(HostSessionStateSnapshot.isAuthoritative(["%5": pane], tmux: tmux))
            #expect(!HostSessionStateSnapshot.isAuthoritative([:], tmux: tmux))
            #expect(!HostSessionStateSnapshot.isAuthoritative(["%5": .init(paneId: "%5")], tmux: tmux))
        }
    }

    @Test("Fan cards are symmetric, bounded and remain finite at small counts", arguments: [1, 2, 5, 7])
    func fan(count: Int) {
        let positions = (0..<count).map { AgentNoteFanPosition(index: $0, count: count, width: 780) }
        for (left, right) in zip(positions, positions.reversed()) {
            #expect(abs(left.x + right.x) < 0.001)
            #expect(left.y == right.y)
            #expect(abs(left.angle + right.angle) < 0.001)
            #expect(abs(left.x) + 120 <= 390)
            #expect(left.y.isFinite && left.x.isFinite && abs(left.angle) <= 12)
        }
    }

    @Test("The native note editor focuses and selects complete Unicode text; Escape stays local", arguments: [false, true])
    func textSelection(existing: Bool) async {
        await withMainSerialExecutor {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let editor = AgentNoteNativeTextView(frame: .init(x: 0, y: 0, width: 500, height: 300))
            let text = "中文 👩🏽‍💻\nsecond line"
            editor.string = existing ? text : ""
            editor.selectOnFocus = existing
            var escaped = false
            editor.onEscape = { escaped = true }
            window.contentView = editor
            defer { window.contentView = nil
                window.close()
            }
            await Task.megaYield()
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == NSRange(location: 0, length: existing ? (text as NSString).length : 0))
            editor.cancelOperation(nil)
            #expect(escaped)
        }
    }

    enum CloseReason: CaseIterable, Sendable { case panel, hostDisconnected, transportInterrupted, terminalClosed }

    @Test("Panel close and both disconnects save drafts; confirmed terminal closure prevents resurrection", arguments: CloseReason.allCases)
    func draftLifecycle(reason: CloseReason) async throws {
        try await withMainSerialExecutor {
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
            } operation: {
                _ = NSApplication.shared
                let store = AgentNotesStore()
                let scope = AgentNoteScope(hostID: "remote", paneID: UUID())
                let manager = try await ViewerConnectionManager()
                let sessions = SessionStore()
                manager.onSessionState = { sessions.handleStateUpdate($0) }
                manager.onHostDisconnected = { sessions.clearSessions(for: $0) }
                manager.onTransportInterrupted = { sessions.clearSessions(for: $0) }
                AppCoordinator.wireAgentNotes(on: manager, into: store)
                let receive = try #require(manager.onSessionState)
                let identity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: scope.paneID)
                let state = SessionStateMessage(
                    pairId: "remote", paneStates: ["%1": .init(paneId: "%1", sessionName: "work", workspaceIdentity: identity)],
                    workspaceIdentity: .init(hostID: UUID(), serverID: identity.serverID), hasAuthoritativePaneSnapshot: true
                )
                receive(state)
                let available = store.availability(for: scope)
                var closeRequest: ((Bool) -> Bool)?
                var closed = false
                let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AgentNotesView(
                    store: store, scope: scope, title: "Fixture Agent", newNote: true,
                    isAvailable: available, registerClose: { closeRequest = $0 }, close: { closed = true }
                ))
                window.contentView = host
                defer {
                    closeRequest = nil
                    window.contentView = nil
                    window.close()
                }
                host.layoutSubtreeIfNeeded()
                await Task.megaYield()
                func editor(in view: NSView) -> AgentNoteNativeTextView? {
                    if let editor = view as? AgentNoteNativeTextView {
                        return editor
                    }
                    return view.subviews.lazy.compactMap { editor(in: $0) }.first
                }
                let textView = try #require(editor(in: host))
                #expect(window.firstResponder === textView)
                #expect((textView.enclosingScrollView?.contentSize.height ?? 0) > 200)
                #expect((textView.textContainer?.containerSize.width ?? 0) > 200)
                textView.insertText("  A pasted thought 👩🏽‍💻\n", replacementRange: .init(location: 0, length: 0))
                await Task.megaYield()
                switch reason {
                case .panel: break
                case .hostDisconnected: await manager.onHostDisconnected?("remote")
                case .transportInterrupted: await manager.onTransportInterrupted?("remote")
                case .terminalClosed:
                    receive(SessionStateMessage(pairId: "remote", paneStates: [:], workspaceIdentity: state.workspaceIdentity, hasAuthoritativePaneSnapshot: true))
                }
                let paneClosed = reason == .terminalClosed
                #expect(available() == !paneClosed)
                if reason != .panel {
                    #expect(sessions.windows(for: "remote").isEmpty)
                }
                let finish = try #require(closeRequest)
                _ = finish(false)
                #expect(closed)
                #expect(store.notes(for: scope).map(\.text) == (paneClosed ? [] : ["  A pasted thought 👩🏽‍💻\n"]))
                if !paneClosed {
                    receive(state)
                }
                #expect(AgentNotesStore().notes(for: scope).map(\.text) == (paneClosed ? [] : ["  A pasted thought 👩🏽‍💻\n"]))
            }
        }
    }

    @Test("Render the note-card fan in an isolated native view", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_AGENT_NOTES_PREVIEW"] != nil))
    func renderPreview() throws {
        _ = NSApplication.shared
        let texts = ["接下来要做\n\n把交互再打磨一点。\n让记录一个想法像呼吸一样轻。", "常用命令\n\ngit status --short\nswift test", "一段灵感\n\n卡片沿弧线展开，\n像桌面上随手铺开的便签。", "下次继续\n\n记得检查保存后的反馈。", "给未来的自己\n\n保持简单。\n先把重要的一件事做好。"]
        let preview = VStack(alignment: .leading, spacing: 20) {
            Text("Agent Notes").font(.title2.bold()).padding(.horizontal, 24)
            ZStack {
                ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                    let position = AgentNoteFanPosition(index: index, count: texts.count, width: 840)
                    AgentNoteCard(note: .init(id: UUID(), text: text, createdAt: .now, updatedAt: .now), colorIndex: index, selected: index == 2)
                        .rotationEffect(.degrees(position.angle), anchor: .bottom)
                        .offset(x: position.x, y: position.y)
                        .zIndex(index == 2 ? 100 : Double(index))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("⌘⇧N 新建便签    ⌘⌥N 打开列表    Esc 保存并关闭").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
        }
        .padding(.vertical, 28).frame(width: 880, height: 480)
        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: preview)
        host.frame = .init(x: 0, y: 0, width: 880, height: 480)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = try #require(ProcessInfo.processInfo.environment["CTRLX_AGENT_NOTES_PREVIEW"])
        try data.write(to: URL(fileURLWithPath: output))
    }
}
