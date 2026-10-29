import CtrlxCommon
import CtrlxNetworking
import CtrlxSimulatorProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    var independentResourceCatalog: IndependentResourceCatalog {
        let sessions = resourceSessions.sessions
        let ids = Set(sessions.map(\.id))
        // Native close callbacks can outlive the session's explicit removal.
        return .init(
            sessions: sessions,
            files: hostFileTabs.tabs.filter { $0.resourceSessionID.map(ids.contains) == true },
            browsers: agentBrowser.sharedBrowserTabs.filter { $0.resourceSessionID.map(ids.contains) == true },
            simulators: agentSimulator.sharedSimulatorTabs.filter { $0.resourceSessionID.map(ids.contains) == true }
        )
    }

    func updateResourceSessions(_ panes: [PaneInfo]) {
        resourceSessions.update(panes)
        refreshResourceSessions()
        hostFileTabs.updateResourceSessions(resourceSessions.sessions)
        agentBrowser.updateResourceSessions(resourceSessions.sessions)
        agentSimulator.updateResourceSessions(resourceSessions.sessions)
    }

    func refreshResourceSessions() {
        let ids = hostFileTabs.tabs.compactMap(\.resourceSessionID)
            + agentBrowser.sharedBrowserTabs.compactMap(\.resourceSessionID)
            + agentSimulator.sharedSimulatorTabs.compactMap(\.resourceSessionID)
        resourceSessions.retainResources(in: Set(ids))
        tmuxService.resourceSessions = resourceSessions.sessions.filter { (try? resourceSessions.resolve($0.id)) != nil }
    }

    func handleResourceTab(_ request: ResourceTabRequest) async throws -> ResourceTabResponse {
        let session = try resourceSessions.reserve(request.sessionID)
        defer {
            resourceSessions.release(session.id)
            refreshResourceSessions()
        }
        switch request.operation {
        case let .open(kind, location):
            switch kind {
            case .files:
                return try .init(file: hostFileTabs.open(session: session, directory: location))
            case .browser:
                let url: URL?
                if let location {
                    guard let parsed = URL(string: location), BrowserWebURL.isSupported(parsed) else {
                        throw FileBrowserError.message("Enter an HTTP or HTTPS address.")
                    }
                    url = parsed
                } else {
                    url = nil
                }
                let tab = try await agentBrowser.openResourceBrowser(session: session, url: url)
                do { _ = try resourceSessions.resolve(session.id) }
                catch {
                    agentBrowser.closeResourceSession(session.id)
                    throw error
                }
                guard let descriptor = agentBrowser.sharedBrowserTabs.first(where: { $0.id == tab.id }) else {
                    throw FileBrowserError.message("The browser tab closed while opening.")
                }
                return .init(browser: descriptor)
            case .simulator:
                return try await .init(simulator: agentSimulator.openResourceSimulator(session: session) { [weak self] in
                    guard let self else { throw CancellationError() }
                    _ = try self.resourceSessions.resolve(session.id)
                })
            }
        case .closeSession:
            try await closeResourceSession(session)
            return .init()
        case let .sendPath(tabID, path, agentID):
            @Dependency(SimulatorSystemClient.self) var system
            guard
                hostFileTabs.tabs.contains(where: { $0.id == tabID && $0.resourceSessionID == session.id }),
                path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 8_192,
                let target = try await resourceAgents(in: session.id).first(where: { $0.agent.id == agentID }),
                let pane = tmuxService.panes.first(where: { $0.paneId == target.agent.paneID && $0.workspaceIdentity?.sessionID == session.id }),
                let identity = pane.workspaceIdentity,
                try system.inspect(target.owner.pid).owner == target.owner,
                let content = DroppedPathFormatter.format(urls: [URL(fileURLWithPath: path)]) else {
                throw FileBrowserError.message("The file tab or chosen Agent changed. Choose the recipient again.")
            }
            try await tmuxService.loadAndPasteBuffer(target: pane.paneId, content: " \(content) ", bufferName: "ctrlx-path-\(UUID().uuidString)", expectedWorkspacePane: identity)
            return .init()
        case .agents:
            return try await .init(agents: resourceAgents(in: session.id).map(\.agent))
        case let .authorize(kind, tabID, agentID):
            try await authorizeResource(kind, tabID: tabID, sessionID: session.id, agentID: agentID)
            return .init()
        case let .revoke(kind, tabID):
            try revokeResource(kind, tabID: tabID, sessionID: session.id)
            return .init()
        case let .returnControl(kind, tabID):
            let grant: ResourceTabGrant?
            switch kind {
            case .browser: grant = agentBrowser.sharedBrowserTabs.first { $0.id == tabID && $0.resourceSessionID == session.id }?.grant
            case .simulator: grant = agentSimulator.sharedSimulatorTabs.first { $0.id == tabID && $0.resourceSessionID == session.id }?.grant
            case .files: grant = nil
            }
            guard let grant else { throw FileBrowserError.message("This tab has no active Agent authorization.") }
            try await authorizeResource(kind, tabID: tabID, sessionID: session.id, agentID: grant.agent.id)
            return .init()
        }
    }

    struct ResourceAgentTarget {
        let agent: ResourceAgent
        let owner: SimulatorOwner
    }

    func resourceAgents(in sessionID: UUID) async throws -> [ResourceAgentTarget] {
        @Dependency(SimulatorSystemClient.self) var system
        guard
            let registry = pluginRegistry,
            let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true) else {
            throw FileBrowserError.message("Cannot inspect running Agents. Try again after the Host is ready.")
        }
        _ = try resourceSessions.resolve(sessionID)
        return detected.keys.sorted().compactMap { paneID in
            guard
                let candidate = detected[paneID], candidate.processIDs.count == 1,
                let process = candidate.processIDs.first, let pid = Int32(process),
                let pane = tmuxService.panes.first(where: { $0.paneId == paneID && $0.workspaceIdentity?.sessionID == sessionID }),
                let owner = try? system.inspect(pid).owner else { return nil }
            return .init(agent: .init(id: owner.key, title: "\(pane.windowName) · \(candidate.pluginID)", paneID: paneID), owner: owner)
        }
    }

    private func authorizeResource(_ kind: ResourceTabKind, tabID: UUID, sessionID: UUID, agentID: String) async throws {
        guard let target = try await resourceAgents(in: sessionID).first(where: { $0.agent.id == agentID }) else {
            throw FileBrowserError.message("The chosen Agent is no longer running in this session.")
        }
        let conversation = await resourceIdentity(for: target.owner)
        switch kind {
        case .browser: try agentBrowser.setResourceGrant(tabID: tabID, sessionID: sessionID, agent: target.agent, owner: target.owner, conversation: conversation)
        case .simulator: try await agentSimulator.setResourceGrant(tabID: tabID, sessionID: sessionID, agent: target.agent, owner: target.owner, conversation: conversation)
        case .files: throw FileBrowserError.message("Files supports sending paths, not Agent control.")
        }
        do {
            guard try await resourceAgents(in: sessionID).contains(where: { $0.owner == target.owner && $0.agent.paneID == target.agent.paneID }) else {
                throw FileBrowserError.message("The Agent moved or exited during authorization.")
            }
        } catch {
            // A second Viewer may already have authorized a different Agent.
            let current = kind == .browser
                ? agentBrowser.sharedBrowserTabs.first(where: { $0.id == tabID })?.grant
                : agentSimulator.sharedSimulatorTabs.first(where: { $0.id == tabID })?.grant
            if current?.agent.id == target.agent.id {
                try revokeResource(kind, tabID: tabID, sessionID: sessionID)
            }
            throw error
        }
    }

    private func revokeResource(_ kind: ResourceTabKind, tabID: UUID, sessionID: UUID) throws {
        switch kind {
        case .browser: try agentBrowser.revokeResourceGrant(tabID: tabID, sessionID: sessionID)
        case .simulator: try agentSimulator.revokeResourceGrant(tabID: tabID, sessionID: sessionID)
        case .files: throw FileBrowserError.message("Files has no Agent authorization.")
        }
    }

    func closeResourceSession(_ session: ResourceSession) async throws {
        let sourcePanes = Set(tmuxService.panes.filter { $0.workspaceIdentity?.sessionID == session.id }.map(\.paneId))
        let browserIDs = Set(agentBrowser.sharedBrowserTabs.filter { $0.sourcePaneID.map(sourcePanes.contains) == true }.map(\.id))
        let simulatorIDs = Set(agentSimulator.sharedSimulatorTabs.filter { $0.sourcePaneID.map(sourcePanes.contains) == true }.map(\.id))
        resourceSessions.beginClosing(session.id)
        refreshResourceSessions()
        do {
            if let pane = tmuxService.panes.first(where: { $0.workspaceIdentity?.sessionID == session.id }) {
                try await tmuxService.killSession(pane.sessionName, expectedWorkspacePane: pane.workspaceIdentity)
            }
        } catch {
            resourceSessions.cancelClosing(session)
            updateResourceSessions(tmuxService.panes)
            throw error
        }
        resourceSessions.remove(session.id)
        hostFileTabs.closeSession(session.id)
        agentBrowser.closeResourceSession(session.id, including: browserIDs)
        await agentSimulator.closeResourceSession(session.id, including: simulatorIDs)
        refreshResourceSessions()
    }
}
