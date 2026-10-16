import CtrlxBrowserBridge
import CtrlxNetworking
import Foundation
import Logging

@MainActor
final class BrowserExtensionControl {
    let anchorID: UUID
    var lease: BrowserControlLease
    var pageID: UUID?
    var surface: RemoteBrowserExtensionSurface = .manager
    var prepared: [UUID: PreparedBrowserExtension] = [:]
    var upload: (id: UUID, actor: BrowserExtensionUpload, replacing: BrowserExtensionRuntimeItem?)?
    var preparing = false

    init(anchorID: UUID, lease: BrowserControlLease) {
        self.anchorID = anchorID
        self.lease = lease
    }
}

@MainActor
extension AgentBrowserService {
    var supportsBrowserExtensions: Bool {
        guard let runtime else { return false }
        return runtime.responds(to: #selector(CXBrowserRuntime.setExtensionControl(_:forTab:)))
            && runtime.responds(to: #selector(CXBrowserRuntime.requestExtensionSurface(forTab:request:completion:)))
            && runtime.responds(to: #selector(CXBrowserRuntime.requestBrowserExtensions(forTab:request:completion:)))
    }

    func releaseExtensionControl() {
        guard let control = extensionControl else { return }
        extensionControl = nil
        _ = runtime?.setExtensionControl?(nil, forTab: control.anchorID.uuidString)
        tabs[control.anchorID.uuidString]?.isRemotelyControlled = false
        if let page = control.pageID {
            tabs[page.uuidString]?.isRemotelyControlled = false
        }
        let previous = extensionCleanupTask
        let store = extensionStore
        // An install already submitted to Chromium may finish after disconnect.
        // Its immutable package stays until the actual outcome is reconciled.
        extensionCleanupTask = Task {
            await previous?.value
            if let upload = control.upload {
                do { try await upload.actor.close() }
                catch { Logger(label: "com.ctrlx.browser-extensions").error("Extension upload cleanup failed: \(error)") }
            }
            for id in control.prepared.keys {
                do { try await store?.abandon(id) }
                catch { Logger(label: "com.ctrlx.browser-extensions").error("Extension preview cleanup failed: \(error)") }
            }
        }
        onTabsChanged?()
    }

    private func checkExtensionControl(_ control: BrowserExtensionControl) throws {
        guard
            extensionControl === control, control.lease.expires > .now,
            let tab = tabs[control.anchorID.uuidString], !tab.isClosed else {
            throw RemoteBrowserError.message("Extension control expired. Take Control again.")
        }
    }

    func handleBrowserExtensions(
        _ operation: RemoteBrowserExtensionOperation, request: BrowseBrowser,
        tab: AgentBrowserTabState, viewerID: String
    ) async throws -> RemoteBrowserResponse {
        guard supportsBrowserExtensions, let runtime else {
            throw RemoteBrowserError.message("Update the Host Mac to manage browser extensions.")
        }
        if operation == .acquire {
            if let control = extensionControl {
                guard
                    control.anchorID == tab.id, control.lease.viewerID == viewerID,
                    control.lease.surfaceID == request.surfaceID else {
                    throw RemoteBrowserError.message("Another surface controls this Host's extensions. Release it or take control back on the Host.")
                }
                control.lease.expires = .now.advanced(by: .seconds(20))
                _ = try await extensionSurfaceRequest(control, payload: ["action": "ping"])
                return RemoteBrowserResponse(tab: descriptor(tab), controlID: control.lease.id)
            }
            let id = UUID()
            guard
                !extensionOperationInProgress, remoteControls[tab.id] == nil,
                runtime.setExtensionControl?(id.uuidString, forTab: tab.identifier) == true else {
                throw RemoteBrowserError.message("The browser is busy or controlled by another viewer. Release page control before managing extensions.")
            }
            extensionControl = BrowserExtensionControl(anchorID: tab.id, lease: BrowserControlLease(
                id: id, viewerID: viewerID, surfaceID: request.surfaceID, expires: .now.advanced(by: .seconds(20))
            ))
            tab.isRemotelyControlled = true
            startControlExpiry()
            onTabsChanged?()
            return RemoteBrowserResponse(tab: descriptor(tab), controlID: id)
        }
        guard
            let control = extensionControl, control.anchorID == tab.id,
            control.lease.viewerID == viewerID, control.lease.surfaceID == request.surfaceID,
            control.lease.id == request.controlID else {
            if operation == .release || operation == .frame {
                return RemoteBrowserResponse(tab: descriptor(tab))
            }
            throw RemoteBrowserError.message("Extension control expired. Take Control again.")
        }
        if operation == .release {
            releaseExtensionControl()
            return RemoteBrowserResponse(tab: descriptor(tab))
        }
        control.lease.expires = .now.advanced(by: .seconds(20))
        // Upload chunks and network preparation also renew/check the native
        // grant. A Host click can revoke it independently of the relay state.
        do { _ = try await extensionSurfaceRequest(control, payload: ["action": "ping"]) }
        catch {
            if operation == .frame {
                return RemoteBrowserResponse(tab: descriptor(tab))
            }
            throw error
        }
        let id = control.lease.id
        var result = RemoteBrowserExtensionResult()
        var responseTab = tab
        var frame: RemoteBrowserFrame?
        switch operation {
        case .acquire,
             .release: break
        case .list:
            let entries = try await browserExtensions(for: tab, controlID: id)
            result = .init(entries: entries.map { .init(id: $0.id, name: $0.runtime.name, version: $0.runtime.version, state: $0.runtime.state, canUpdate: $0.canUpdate) })
        case .openWindow,
             .showSurface(.page):
            let data = try await extensionSurfaceRequest(control, payload: ["action": "openWindow"])
            struct Opened: Decodable { let tabID: UUID }
            let opened = try JSONDecoder().decode(Opened.self, from: data)
            guard
                let page = tabs[opened.tabID.uuidString], !page.isClosed, page.isExtensionWindow,
                descriptor(page).sessionName == request.sessionName else {
                throw RemoteBrowserError.message("The extension window did not retain its source session.")
            }
            control.pageID = page.id
            control.surface = .page
            page.isRemotelyControlled = true
            responseTab = page
            result = .init(surface: .page)
            onTabsChanged?()
        case .showSurface(.manager):
            _ = try await extensionSurfaceRequest(control, payload: ["action": "showManager"])
            control.surface = .manager
            result = .init(surface: .manager)
        case let .prepareStore(input, replacingID):
            guard !control.preparing, control.prepared.isEmpty, control.upload == nil else {
                throw RemoteBrowserError.message("Finish or discard the current extension package first.")
            }
            control.preparing = true
            defer { control.preparing = false }
            let previous = try await extensionToReplace(replacingID, tab: tab, control: control)
            let prepared = try await prepareStoreExtension(input, for: tab, replacing: previous, controlID: id)
            result = try await rememberExtensionPreview(prepared, control: control)
        case let .beginUpload(uploadID, name, size, replacingID):
            guard !control.preparing, control.prepared.isEmpty, control.upload == nil else {
                throw RemoteBrowserError.message("Finish or discard the current extension package first.")
            }
            control.preparing = true
            defer { control.preparing = false }
            let previous = try await extensionToReplace(replacingID, tab: tab, control: control)
            try checkExtensionControl(control)
            let upload = BrowserExtensionUpload()
            control.upload = (uploadID, upload, previous)
            do {
                try await upload.begin(id: uploadID, name: name, size: size)
                try checkExtensionControl(control)
            } catch {
                control.upload = nil
                try await upload.close()
                throw error
            }
            result = .init(uploadOffset: 0)
        case let .appendUpload(uploadID, offset, data):
            guard !control.preparing, let upload = control.upload, upload.id == uploadID else {
                throw RemoteBrowserError.message("This extension upload expired.")
            }
            result = try .init(uploadOffset: await upload.actor.append(id: uploadID, offset: offset, data: data))
        case let .finishUpload(uploadID, sha256):
            guard !control.preparing, let upload = control.upload, upload.id == uploadID else {
                throw RemoteBrowserError.message("This extension upload expired.")
            }
            control.preparing = true
            defer { control.preparing = false }
            let file = try await upload.actor.finish(id: uploadID, sha256: sha256)
            try checkExtensionControl(control)
            let prepared = try await prepareExtension(file: file, for: tab, replacing: upload.replacing, controlID: id)
            result = try await rememberExtensionPreview(prepared, control: control)
            try await upload.actor.close()
            control.upload = nil
        case let .cancelUpload(uploadID):
            guard !control.preparing, let upload = control.upload, upload.id == uploadID else {
                throw RemoteBrowserError.message("This extension upload is unavailable or busy.")
            }
            control.upload = nil
            try await upload.actor.close()
        case let .install(token):
            guard !control.preparing, let prepared = control.prepared.removeValue(forKey: token) else {
                throw RemoteBrowserError.message("Review this extension's permissions again before installing.")
            }
            control.preparing = true
            defer { control.preparing = false }
            let store = extensionStore
            do { try await installExtension(prepared, for: tab, controlID: id) }
            catch {
                // Consume the preview even on failure. Submitted packages may
                // still become active after a timeout, so only abandon unused ones.
                do { try await store?.abandon(token) }
                catch { Logger(label: "com.ctrlx.browser-extensions").error("Extension preview cleanup failed: \(error)") }
                throw error
            }
        case let .discard(token):
            guard let prepared = control.prepared[token] else {
                throw RemoteBrowserError.message("This extension preview expired.")
            }
            try await cancelExtension(prepared)
            control.prepared.removeValue(forKey: token)
        case let .setEnabled(extensionID, enabled):
            let item = try await extensionItem(extensionID, tab: tab, control: control)
            if enabled {
                _ = try await extensionSurfaceRequest(control, payload: ["action": "showManager"])
                control.surface = .manager
            }
            try await setExtensionEnabled(item.runtime, enabled: enabled, for: tab, controlID: id)
            result = .init(surface: control.surface)
        case let .remove(extensionID):
            let item = try await extensionItem(extensionID, tab: tab, control: control)
            _ = try await extensionSurfaceRequest(control, payload: ["action": "showManager"])
            control.surface = .manager
            try await uninstallExtension(item.runtime, for: tab, controlID: id)
            result = .init(surface: .manager)
        case .frame:
            var payload: [String: Any] = ["action": "frame"]
            if let maximum = request.frameMaxDimension {
                payload["maximumDimension"] = maximum
            }
            let data = try await extensionSurfaceRequest(control, payload: payload)
            let decoded = try JSONDecoder().decode(RemoteBrowserFrame.self, from: data)
            guard decoded.isValid else { throw RemoteBrowserError.message("Invalid extension window frame.") }
            frame = decoded
            result = .init(surface: control.surface)
        case let .text(text):
            _ = try await extensionSurfaceInput(.text(text), request: request, control: control)
        case let .key(key):
            _ = try await extensionSurfaceInput(.key(key), request: request, control: control)
        case let .pointer(pointer):
            _ = try await extensionSurfaceInput(.pointer(pointer), request: request, control: control)
        case let .fit(width, height):
            _ = try await extensionSurfaceInput(.fit(width: width, height: height), request: request, control: control)
        }
        try checkExtensionControl(control)
        try Task.checkCancellation()
        return RemoteBrowserResponse(tab: descriptor(responseTab), frame: frame, controlID: id, extensions: result)
    }

    private func extensionItem(_ id: String, tab: AgentBrowserTabState, control: BrowserExtensionControl) async throws -> BrowserExtensionListEntry {
        let entries = try await browserExtensions(for: tab, controlID: control.lease.id)
        try checkExtensionControl(control)
        guard let item = entries.first(where: { $0.id == id }) else {
            throw RemoteBrowserError.message("The extension is no longer installed. Refresh its state.")
        }
        return item
    }

    private func extensionToReplace(_ id: String?, tab: AgentBrowserTabState, control: BrowserExtensionControl) async throws -> BrowserExtensionRuntimeItem? {
        guard let id else { return nil }
        let item = try await extensionItem(id, tab: tab, control: control)
        guard item.canUpdate else { throw RemoteBrowserError.message("This extension was not installed through CtrlX.") }
        return item.runtime
    }

    private func rememberExtensionPreview(_ package: PreparedBrowserExtension, control: BrowserExtensionControl) async throws -> RemoteBrowserExtensionResult {
        do { try checkExtensionControl(control) }
        catch {
            try await cancelExtension(package)
            throw error
        }
        guard let id = package.preview.extensionID else { throw RemoteBrowserError.message("The package has no verified extension identity.") }
        control.prepared[package.id] = package
        let preview = package.preview
        func source(_ source: BrowserExtensionPackagePreview.Source) -> RemoteBrowserExtensionPreview.Source {
            switch source { case .zip: .zip
            case .crx: .crx
            case .webStore: .webStore }
        }
        return .init(prepared: .init(
            id: package.id, source: source(preview.source), name: preview.name, version: preview.version,
            extensionID: id, sha256: preview.sha256, permissions: preview.permissions,
            hostPermissions: preview.hostPermissions, contentScriptMatches: preview.contentScriptMatches,
            optionalPermissions: preview.optionalPermissions, optionalHostPermissions: preview.optionalHostPermissions,
            previousVersion: package.replacing?.version, previousSource: package.previousSource.map(source)
        ))
    }

    private func extensionSurfaceInput(_ operation: RemoteBrowserOperation, request: BrowseBrowser, control: BrowserExtensionControl) async throws -> Data {
        var payload = try Self.nativePayload(operation)
        guard let generation = request.generation else { throw RemoteBrowserError.message("Wait for an extension frame before sending input.") }
        payload["generation"] = generation
        return try await extensionSurfaceRequest(control, payload: payload)
    }

    private func extensionSurfaceRequest(_ control: BrowserExtensionControl, payload: [String: Any]) async throws -> Data {
        try checkExtensionControl(control)
        guard let runtime, supportsBrowserExtensions else { throw RemoteBrowserError.message("Native extension control is unavailable.") }
        var payload = payload
        payload["lease"] = control.lease.id.uuidString
        let request = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { continuation in
                runtime.requestExtensionSurface?(forTab: control.anchorID.uuidString, request: request) { data, error in
                    if let error {
                        continuation.resume(throwing: RemoteBrowserError.message(error))
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: RemoteBrowserError.message("Native extension control returned no response."))
                    }
                }
            }
        } catch {
            if payload["action"] as? String == "ping", extensionControl === control {
                releaseExtensionControl()
            }
            throw error
        }
        try checkExtensionControl(control)
        return data
    }
}
