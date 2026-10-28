import CtrlxBrowserBridge
import CtrlxCommon
import CtrlxNetworking
import Foundation

struct BrowserControlLease {
    let id: UUID
    let viewerID: String
    let surfaceID: UUID
    var expires: ContinuousClock.Instant
}

enum RemoteBrowserError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self {
            message
        } else {
            nil
        }
    }
}

@MainActor
extension AgentBrowserService {
    var supportsBrowserSharing: Bool {
        // Advertise protocol support before Chromium's first on-demand launch.
        guard let runtime else { return true }
        return runtime.responds(to: #selector(CXBrowserRuntime.requestBrowserTab(_:request:completion:)))
    }

    var sharedBrowserTabs: [RemoteBrowserTab] {
        tabs.values.filter { !$0.isClosed && $0.manualTarget?.hostID == nil }
            .map(descriptor).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func descriptor(_ tab: AgentBrowserTabState) -> RemoteBrowserTab {
        RemoteBrowserTab(
            id: tab.id,
            sessionName: tab.manualTarget?.sessionName ?? tab.sessionName,
            windowID: tab.windowID,
            parentID: tab.parentID,
            title: String(tab.title.prefix(256)),
            url: String(tab.url.prefix(8_192)),
            isLoading: tab.isLoading,
            isAgentOwned: !tab.owner.isEmpty,
            isControlled: tab.isRemotelyControlled,
            sourceAgent: tab.sourceAgent,
            sourcePaneID: tab.paneID,
            isExtensionWindow: tab.isExtensionWindow ? true : nil,
            externalApplicationNotice: tab.externalApplicationNotice,
            networkPermission: tab.networkPermission,
            resourceSessionID: tab.resourceSessionID,
            grant: tab.grant
        )
    }

    func releaseBrowserControl(_ tabID: UUID) {
        stopBrowserAudio(tabID)
        browserAudioRevisions[tabID] = nil
        if extensionControl?.anchorID == tabID || extensionControl?.pageID == tabID {
            releaseExtensionControl()
        }
        guard remoteControls.removeValue(forKey: tabID) != nil else { return }
        _ = runtime?.setHumanControl(nil, forTab: tabID.uuidString)
        tabs[tabID.uuidString]?.isRemotelyControlled = false
        onTabsChanged?()
    }

    func disconnectBrowserViewer(_ viewerID: String) {
        if extensionControl?.lease.viewerID == viewerID {
            releaseExtensionControl()
        }
        for (tab, lease) in remoteControls where lease.viewerID == viewerID {
            releaseBrowserControl(tab)
        }
    }

    func expireBrowserControls() {
        if let control = extensionControl, control.lease.expires <= .now {
            releaseExtensionControl()
        }
        for (tab, lease) in remoteControls where lease.expires <= .now {
            releaseBrowserControl(tab)
        }
    }

    func startControlExpiry() {
        guard controlExpiryTask == nil else { return }
        controlExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard let self else { return }
                self.expireBrowserControls()
                if self.remoteControls.isEmpty && self.extensionControl == nil {
                    break
                }
            }
            self?.controlExpiryTask = nil
        }
    }

    func handleBrowser(_ request: BrowseBrowser, viewerID: String) async throws -> RemoteBrowserResponse {
        try Task.checkCancellation()
        expireBrowserControls()
        switch request.operation {
        case .create,
             .openPane:
            guard let paneID = request.sourcePaneID, !paneID.isEmpty else {
                throw RemoteBrowserError.message("Open Browser from a terminal Window to select its source pane.")
            }
            var url: URL?
            if case let .openPane(address) = request.operation, let address {
                guard let parsed = URL(string: address), BrowserWebURL.isSupported(parsed) else {
                    throw RemoteBrowserError.message("Only HTTP and HTTPS links without embedded usernames or passwords can open in the Host browser.")
                }
                url = parsed
            }
            let tab = try await openPaneBrowser(sessionName: request.sessionName, paneID: paneID, url: url)
            return RemoteBrowserResponse(tab: descriptor(tab))
        default: break
        }
        guard supportsBrowserSharing, let runtime else { throw RemoteBrowserError.message("Update the Host Mac to share Chromium pages.") }
        guard
            let tabID = request.tabID, let tab = tabs[tabID.uuidString], !tab.isClosed,
            tab.manualTarget?.hostID == nil, descriptor(tab).sessionName == request.sessionName else {
            throw RemoteBrowserError.message("This Host browser tab is no longer available in the session.")
        }
        switch request.operation {
        case let .audio(streamID, revision, enabled):
            guard !tab.isExtensionWindow, let lease = renewBrowserControl(request, viewerID: viewerID) else {
                throw RemoteBrowserError.message("Take Control of the page before receiving sound.")
            }
            try configureBrowserAudio(tabID: tabID, lease: lease, streamID: streamID, revision: revision, enabled: enabled)
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: lease.id)
        case let .networkPermission(id, allow):
            guard let lease = renewBrowserControl(request, viewerID: viewerID) else {
                throw RemoteBrowserError.message("Control expired. Take Control again.")
            }
            try await respondToNetworkPermission(id, tab: tab, allow: allow, controlID: lease.id)
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: lease.id)
        case let .extensions(operation):
            return try await handleBrowserExtensions(operation, request: request, tab: tab, viewerID: viewerID)
        case .close:
            guard extensionControl?.anchorID != tabID, extensionControl?.pageID != tabID else {
                throw RemoteBrowserError.message("Release extension control before closing this page.")
            }
            if let lease = remoteControls[tabID] {
                guard lease.viewerID == viewerID else { throw RemoteBrowserError.message("Another viewer controls this page.") }
            } else {
                guard runtime.setHumanControl(UUID().uuidString, forTab: tabID.uuidString) else {
                    throw RemoteBrowserError.message("Agent page operation is still running. Try closing when it finishes.")
                }
            }
            runtime.closeTab(tabID.uuidString)
            return RemoteBrowserResponse()
        case .takeControl:
            guard extensionControl?.anchorID != tabID, extensionControl?.pageID != tabID else {
                throw RemoteBrowserError.message("This page belongs to an extension control grant.")
            }
            guard !tab.isExtensionWindow else {
                throw RemoteBrowserError.message("Use extension window control for this page. A page control grant cannot control Chrome's native window.")
            }
            if let lease = remoteControls[tabID] {
                guard lease.viewerID == viewerID, lease.surfaceID == request.surfaceID else {
                    throw RemoteBrowserError.message("Another viewer controls this page. Ask them to release it, or take it back on the Host.")
                }
                return RemoteBrowserResponse(tab: descriptor(tab), controlID: lease.id)
            }
            let id = UUID()
            guard runtime.setHumanControl(id.uuidString, forTab: tabID.uuidString) else {
                throw RemoteBrowserError.message("The Agent is still performing a page operation. Try Take Control when it finishes.")
            }
            remoteControls[tabID] = BrowserControlLease(
                id: id,
                viewerID: viewerID,
                surfaceID: request.surfaceID,
                expires: .now.advanced(by: .seconds(20))
            )
            tab.isRemotelyControlled = true
            startControlExpiry()
            onTabsChanged?()
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: id)
        case .releaseControl:
            if
                let lease = remoteControls[tabID], lease.viewerID == viewerID,
                lease.surfaceID == request.surfaceID, lease.id == request.controlID {
                releaseBrowserControl(tabID)
            }
            return RemoteBrowserResponse(tab: descriptor(tab))
        case .frame:
            var payload: [String: Any] = ["action": "frame"]
            if let dimension = request.frameMaxDimension {
                guard (256...RemoteBrowserFrame.maximumDimension).contains(dimension) else {
                    throw RemoteBrowserError.message("Unsupported browser frame size.")
                }
                payload["maximumDimension"] = dimension
            }
            guard remoteCaptures.count < 4 else { throw RemoteBrowserError.message("Browser capture is busy. Try again shortly.") }
            let captureID = UUID()
            remoteCaptures.insert(captureID)
            defer { remoteCaptures.remove(captureID) }
            let data = try await nativeBrowserRequest(tabID, payload: payload)
            try Task.checkCancellation()
            let frame = try JSONDecoder().decode(RemoteBrowserFrame.self, from: data)
            guard frame.isValid else { throw RemoteBrowserError.message("Invalid or oversized browser frame.") }
            let lease = renewBrowserControl(request, viewerID: viewerID)
            return RemoteBrowserResponse(tab: descriptor(tab), frame: frame, controlID: lease?.id)
        default:
            guard let lease = renewBrowserControl(request, viewerID: viewerID) else {
                throw RemoteBrowserError.message("Control expired. Take Control again.")
            }
            var payload = try Self.nativePayload(request.operation)
            payload["lease"] = lease.id.uuidString
            payload["generation"] = request.generation
            let data = try await nativeBrowserRequest(tabID, payload: payload)
            try Task.checkCancellation()
            guard !tab.isClosed, remoteControls[tabID]?.id == lease.id else {
                throw RemoteBrowserError.message("Control changed before the operation completed.")
            }
            var clipboard: WorkspaceClipboardContent?
            if request.operation == .copy {
                let content = try JSONDecoder().decode(WorkspaceClipboardContent.self, from: data)
                clipboard = try WorkspaceClipboard.prepare(content)
            }
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: lease.id, clipboard: clipboard)
        }
    }

    private func renewBrowserControl(_ request: BrowseBrowser, viewerID: String) -> BrowserControlLease? {
        guard
            let id = request.tabID, var lease = remoteControls[id], lease.viewerID == viewerID,
            lease.surfaceID == request.surfaceID, lease.id == request.controlID else { return nil }
        lease.expires = .now.advanced(by: .seconds(20))
        remoteControls[id] = lease
        return lease
    }

    func annotationScreenshot(_ tab: AgentBrowserTabState) async throws -> Data {
        guard !tab.isClosed else { throw RemoteBrowserError.message("This browser tab was closed.") }
        guard remoteCaptures.count < 4 else { throw RemoteBrowserError.message("Browser capture is busy. Try again shortly.") }
        let captureID = UUID()
        remoteCaptures.insert(captureID)
        defer { remoteCaptures.remove(captureID) }
        let data = try await nativeBrowserRequest(tab.id, payload: ["action": "frame", "maximumDimension": RemoteBrowserFrame.maximumDimension])
        let frame = try JSONDecoder().decode(RemoteBrowserFrame.self, from: data)
        guard frame.isValid else { throw RemoteBrowserError.message("Invalid browser screenshot.") }
        return frame.jpeg
    }

    private func nativeBrowserRequest(_ tabID: UUID, payload: [String: Any]) async throws -> Data {
        guard let runtime else { throw RemoteBrowserError.message("Browser is unavailable.") }
        let request = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            runtime.requestBrowserTab(tabID.uuidString, request: request) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RemoteBrowserError.message(error ?? "Browser request failed."))
                }
            }
        }
    }

    static func nativePayload(_ operation: RemoteBrowserOperation) throws -> [String: Any] {
        switch operation {
        case let .navigate(url):
            guard url.utf8.count <= 8_192 else { throw RemoteBrowserError.message("Address is too long.") }
            return ["action": "navigate", "url": url]
        case .back: return ["action": "back"]
        case .forward: return ["action": "forward"]
        case .reload: return ["action": "reload"]
        case .close: return ["action": "close"]
        case .copy: return ["action": "copy"]
        case let .paste(content):
            guard content.isValid else { throw RemoteBrowserError.message("Invalid or oversized clipboard content.") }
            return ["action": "paste", "kind": content.kind.rawValue, "data": content.data.base64EncodedString()]
        case let .fit(width, height):
            guard (240...2_560).contains(width), (240...2_560).contains(height) else {
                throw RemoteBrowserError.message("Unsupported viewport size.")
            }
            return ["action": "fit", "width": width, "height": height]
        case let .text(text):
            guard text.utf8.count <= 16_000 else { throw RemoteBrowserError.message("Paste at most 16 KB of text at a time.") }
            return ["action": "text", "text": text]
        case let .key(key):
            guard key.key.utf8.count <= 32, (0...255).contains(key.keyCode), (0...15).contains(key.modifiers) else {
                throw RemoteBrowserError.message("Invalid keyboard input.")
            }
            return ["action": "key", "key": key.key, "keyCode": key.keyCode, "modifiers": key.modifiers]
        case let .pointer(event):
            guard event.isValid else { throw RemoteBrowserError.message("Invalid pointer input.") }
            let type = switch event.kind {
            case .down: "mousePressed"
            case .up: "mouseReleased"
            case .move: "mouseMoved"
            case .scroll: "mouseWheel"
            }
            return [
                "action": "mouse",
                "type": type,
                "x": event.x,
                "y": event.y,
                "deltaX": event.deltaX,
                "deltaY": event.deltaY,
                "button": event.button.rawValue,
                "buttons": event.buttons,
                "modifiers": event.modifiers,
                "clickCount": event.clickCount,
            ]
        default: throw RemoteBrowserError.message("This operation is handled by the Host registry.")
        }
    }
}
