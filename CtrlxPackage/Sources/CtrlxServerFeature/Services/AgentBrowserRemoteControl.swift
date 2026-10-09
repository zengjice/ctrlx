import CtrlxBrowserBridge
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
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

@MainActor
extension AgentBrowserService {
    var supportsBrowserSharing: Bool {
        runtime?.responds(to: #selector(CXBrowserRuntime.requestBrowserTab(_:request:completion:))) == true
    }

    var sharedBrowserTabs: [RemoteBrowserTab] {
        tabs.values.filter { !$0.isClosed && $0.manualTarget?.hostID == nil }
            .map(descriptor).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func descriptor(_ tab: AgentBrowserTabState) -> RemoteBrowserTab {
        RemoteBrowserTab(id: tab.id, sessionName: tab.manualTarget?.sessionName ?? tab.sessionName,
                         windowID: tab.windowID, parentID: tab.parentID, title: String(tab.title.prefix(256)), url: String(tab.url.prefix(8192)),
                         isLoading: tab.isLoading, isAgentOwned: !tab.owner.isEmpty,
                         isControlled: remoteControls[tab.id] != nil)
    }

    func releaseBrowserControl(_ tabID: UUID) {
        guard remoteControls.removeValue(forKey: tabID) != nil else { return }
        _ = runtime?.setHumanControl(nil, forTab: tabID.uuidString)
        tabs[tabID.uuidString]?.isRemotelyControlled = false
        onTabsChanged?()
    }

    func disconnectBrowserViewer(_ viewerID: String) {
        for (tab, lease) in remoteControls where lease.viewerID == viewerID { releaseBrowserControl(tab) }
    }

    private func expireBrowserControls() {
        for (tab, lease) in remoteControls where lease.expires <= .now { releaseBrowserControl(tab) }
    }

    private func startControlExpiry() {
        guard controlExpiryTask == nil else { return }
        controlExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard let self else { return }
                self.expireBrowserControls()
                if self.remoteControls.isEmpty { break }
            }
            self?.controlExpiryTask = nil
        }
    }

    func handleBrowser(_ request: BrowseBrowser, viewerID: String) async throws -> RemoteBrowserResponse {
        guard supportsBrowserSharing, let runtime else { throw RemoteBrowserError.message("Update the Host Mac to share Chromium pages.") }
        try Task.checkCancellation()
        expireBrowserControls()
        if request.operation == .create {
            let tab = try await createSharedTab(sessionName: request.sessionName)
            return RemoteBrowserResponse(tab: descriptor(tab))
        }
        guard let tabID = request.tabID, let tab = tabs[tabID.uuidString], !tab.isClosed,
              tab.manualTarget?.hostID == nil, descriptor(tab).sessionName == request.sessionName else {
            throw RemoteBrowserError.message("This Host browser tab is no longer available in the session.")
        }
        switch request.operation {
        case .close:
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
            remoteControls[tabID] = BrowserControlLease(id: id, viewerID: viewerID, surfaceID: request.surfaceID,
                                                       expires: .now.advanced(by: .seconds(20)))
            tab.isRemotelyControlled = true
            startControlExpiry()
            onTabsChanged?()
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: id)
        case .releaseControl:
            if let lease = remoteControls[tabID], lease.viewerID == viewerID,
               lease.surfaceID == request.surfaceID, lease.id == request.controlID { releaseBrowserControl(tabID) }
            return RemoteBrowserResponse(tab: descriptor(tab))
        case .frame:
            guard remoteCaptures.count < 4 else { throw RemoteBrowserError.message("Browser capture is busy. Try again shortly.") }
            let captureID = UUID()
            remoteCaptures.insert(captureID)
            defer { remoteCaptures.remove(captureID) }
            let data = try await nativeBrowserRequest(tabID, payload: ["action": "frame"])
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
            _ = try await nativeBrowserRequest(tabID, payload: payload)
            return RemoteBrowserResponse(tab: tab.isClosed ? nil : descriptor(tab), controlID: lease.id)
        }
    }

    private func renewBrowserControl(_ request: BrowseBrowser, viewerID: String) -> BrowserControlLease? {
        guard let id = request.tabID, var lease = remoteControls[id], lease.viewerID == viewerID,
              lease.surfaceID == request.surfaceID, lease.id == request.controlID else { return nil }
        lease.expires = .now.advanced(by: .seconds(20))
        remoteControls[id] = lease
        return lease
    }

    private func nativeBrowserRequest(_ tabID: UUID, payload: [String: Any]) async throws -> Data {
        guard let runtime else { throw RemoteBrowserError.message("Browser is unavailable.") }
        let request = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            runtime.requestBrowserTab(tabID.uuidString, request: request) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: RemoteBrowserError.message(error ?? "Browser request failed.")) }
            }
        }
    }

    static func nativePayload(_ operation: RemoteBrowserOperation) throws -> [String: Any] {
        switch operation {
        case let .navigate(url):
            guard url.utf8.count <= 8192 else { throw RemoteBrowserError.message("Address is too long.") }
            return ["action": "navigate", "url": url]
        case .back: return ["action": "back"]
        case .forward: return ["action": "forward"]
        case .reload: return ["action": "reload"]
        case .close: return ["action": "close"]
        case let .fit(width, height):
            guard (240...2560).contains(width), (240...2560).contains(height) else {
                throw RemoteBrowserError.message("Unsupported viewport size.")
            }
            return ["action": "fit", "width": width, "height": height]
        case let .text(text):
            guard text.utf8.count <= 16000 else { throw RemoteBrowserError.message("Paste at most 16 KB of text at a time.") }
            return ["action": "text", "text": text]
        case let .key(key):
            guard key.key.utf8.count <= 32, (0...255).contains(key.keyCode), (0...15).contains(key.modifiers) else {
                throw RemoteBrowserError.message("Invalid keyboard input.")
            }
            return ["action": "key", "key": key.key, "keyCode": key.keyCode, "modifiers": key.modifiers]
        case let .pointer(event):
            guard event.isValid else { throw RemoteBrowserError.message("Invalid pointer input.") }
            let type: String = switch event.kind {
            case .down: "mousePressed"
            case .up: "mouseReleased"
            case .move: "mouseMoved"
            case .scroll: "mouseWheel"
            }
            return ["action": "mouse", "type": type, "x": event.x, "y": event.y,
                    "deltaX": event.deltaX, "deltaY": event.deltaY, "button": event.button.rawValue,
                    "buttons": event.buttons, "modifiers": event.modifiers, "clickCount": event.clickCount]
        default: throw RemoteBrowserError.message("This operation is handled by the Host registry.")
        }
    }
}
