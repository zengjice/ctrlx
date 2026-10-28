#if os(macOS)
    import CtrlxBrowserBridge
    import CtrlxNetworking
    import Dependencies
    import Foundation

    struct BrowserExtensionListEntry: Identifiable, Sendable {
        let runtime: BrowserExtensionRuntimeItem
        let canUpdate: Bool
        var id: String {
            runtime.id
        }
    }

    extension AgentBrowserService {
        private struct ExtensionSnapshot: Decodable {
            let extensions: [BrowserExtensionRuntimeItem]
            let chromiumVersion: String?
        }

        func browserExtensions(for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws -> [BrowserExtensionListEntry] {
            let items = try await requestExtensions(["operation": "list"], for: tab, controlID: controlID)
            var entries: [BrowserExtensionListEntry] = []
            for item in items {
                let managed = await extensionStore?.isManaged(item) ?? false
                entries.append(BrowserExtensionListEntry(runtime: item, canUpdate: managed))
            }
            return entries.sorted { $0.runtime.name.localizedStandardCompare($1.runtime.name) == .orderedAscending }
        }

        func openExtensionStore(for source: AgentBrowserTabState, url: String = BrowserExtensionStoreURL.home, controlID: UUID? = nil) async throws -> AgentBrowserTabState {
            guard BrowserExtensionStoreURL.isStore(url), let destination = URL(string: url) else {
                throw BrowserExtensionPackageError("Only Chrome Web Store pages can open from extension management.")
            }
            _ = try extensionRuntime(for: source, controlID: controlID)
            let control = controlID == nil ? nil : extensionControl
            if let control {
                _ = try await extensionSurfaceRequest(control, payload: ["action": "ping"])
            }
            let opened: AgentBrowserTabState
            if let id = source.resourceSessionID, let resolveResourceSession {
                opened = try await openResourceBrowser(session: resolveResourceSession(id), url: destination)
            } else if let paneID = source.paneID {
                opened = try await openPaneBrowser(sessionName: source.sessionName, paneID: paneID, url: destination)
            } else {
                throw RemoteBrowserError.message("The source session is no longer available.")
            }
            do {
                try Task.checkCancellation()
                _ = try extensionRuntime(for: source, controlID: controlID)
                if let control {
                    _ = try await extensionSurfaceRequest(control, payload: ["action": "ping"])
                }
            } catch {
                runtime?.closeTab(opened.identifier)
                throw error
            }
            opened.url = destination.absoluteString
            if controlID == nil {
                opened.suppressInitialSelection = false
                browserTabSelected(opened.identifier)
            }
            return opened
        }

        func openExtensionOptions(_ item: BrowserExtensionRuntimeItem, for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws {
            guard item.isEnabled, item.hasOptions == true else {
                throw BrowserExtensionPackageError("This extension has no available settings page.")
            }
            _ = try await requestExtensions(["operation": "openOptions", "id": item.id], for: tab, controlID: controlID)
        }

        func prepareExtension(file: URL, for tab: AgentBrowserTabState, replacing: BrowserExtensionRuntimeItem? = nil, controlID: UUID? = nil) async throws -> PreparedBrowserExtension {
            _ = try extensionRuntime(for: tab, controlID: controlID)
            guard let extensionStore else { throw BrowserExtensionPackageError("The Host extension store is unavailable.") }
            let access = file.startAccessingSecurityScopedResource()
            defer {
                if access {
                    file.stopAccessingSecurityScopedResource()
                }
            }
            let result = try await extensionStore.prepare(file: file, replacing: replacing)
            do { _ = try extensionRuntime(for: tab, controlID: controlID) }
            catch {
                try await extensionStore.cancel(result.id)
                throw error
            }
            return result
        }

        func cancelExtension(_ package: PreparedBrowserExtension) async throws {
            guard let extensionStore else { throw BrowserExtensionPackageError("The Host extension store is unavailable.") }
            try await extensionStore.cancel(package.id)
        }

        func prepareStoreExtension(_ input: String, for tab: AgentBrowserTabState, replacing: BrowserExtensionRuntimeItem? = nil, controlID: UUID? = nil) async throws -> PreparedBrowserExtension {
            guard let extensionStore else { throw BrowserExtensionPackageError("The Host extension store is unavailable.") }
            let identifier = try BrowserExtensionWebStore.identifier(from: input)
            if let replacing, replacing.id != identifier {
                throw BrowserExtensionPackageError("The store link does not match the extension being updated.")
            }
            let snapshot = try await requestExtensionSnapshot(["operation": "list"], for: tab, controlID: controlID)
            guard let version = snapshot.chromiumVersion else {
                throw BrowserExtensionPackageError("Update this Host to download Chrome Web Store packages.")
            }
            @Dependency(BrowserExtensionDownloadClient.self) var downloader
            let data = try await downloader.download(identifier, version)
            _ = try extensionRuntime(for: tab, controlID: controlID)
            let result = try await extensionStore.prepare(data: data, source: .webStore, replacing: replacing, expectedStoreID: identifier)
            do { _ = try extensionRuntime(for: tab, controlID: controlID) }
            catch {
                try await extensionStore.cancel(result.id)
                throw error
            }
            return result
        }

        func installExtension(_ package: PreparedBrowserExtension, for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws {
            guard !extensionOperationInProgress, let extensionStore else {
                throw BrowserExtensionPackageError("Another extension operation is in progress, or the Host store is unavailable.")
            }
            extensionOperationInProgress = true
            defer { extensionOperationInProgress = false }
            let package = try await extensionStore.prepared(package.id)
            let installed = try await requestExtensions(["operation": "list"], for: tab, controlID: controlID)
            let directory = try await extensionStore.beginInstall(package.id, installed: installed)
            let confirmed: [BrowserExtensionRuntimeItem]
            do {
                var result = try await requestExtensions(["operation": "install", "path": directory.path], for: tab, controlID: controlID)
                if
                    package.replacing?.isEnabled == false, let identifier = package.preview.extensionID,
                    result.contains(where: { $0.id == identifier && $0.isEnabled }) {
                    result = try await requestExtensions(["operation": "setEnabled", "id": identifier, "enabled": false], for: tab, controlID: controlID)
                }
                _ = try await extensionStore.confirmInstall(package.id, installed: result)
                confirmed = result
            } catch {
                // A timed-out native operation remains busy. The list request
                // will fail too, so never race it with a guessed rollback.
                if let previous = package.replacing {
                    do {
                        let current = try await requestExtensions(["operation": "list"], for: tab, controlID: controlID)
                        let active = current.first { $0.id == previous.id }
                        if active?.path != previous.path {
                            guard active == nil || active?.path == directory.path else {
                                throw BrowserExtensionPackageError("The extension was changed by another operation.")
                            }
                            let oldDirectory = try await extensionStore.managedDirectory(previous)
                            var restored = try await requestExtensions(["operation": "install", "path": oldDirectory.path], for: tab, controlID: controlID)
                            if !previous.isEnabled {
                                restored = try await requestExtensions(["operation": "setEnabled", "id": previous.id, "enabled": false], for: tab, controlID: controlID)
                            }
                            guard restored.contains(where: { $0.id == previous.id && $0.version == previous.version && $0.path == previous.path && $0.isEnabled == previous.isEnabled }) else {
                                throw BrowserExtensionPackageError("Chromium has not confirmed the previous version was restored.")
                            }
                        }
                    } catch let recoveryError {
                        throw BrowserExtensionPackageError("\(error.localizedDescription) Previous package files were kept. Recovery could not be confirmed: \(recoveryError.localizedDescription)")
                    }
                }
                throw error
            }
            do { try await extensionStore.retirePrevious(package.id, installed: confirmed) }
            catch {
                // Cleanup errors must not roll back a confirmed working install,
                // particularly after part of the old package has been removed.
                throw BrowserExtensionPackageError("The extension is installed, but previous package cleanup failed: \(error.localizedDescription)")
            }
        }

        func setExtensionEnabled(_ item: BrowserExtensionRuntimeItem, enabled: Bool, for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws {
            guard !extensionOperationInProgress else { throw BrowserExtensionPackageError("Another extension operation is in progress.") }
            extensionOperationInProgress = true
            defer { extensionOperationInProgress = false }
            let result = try await requestExtensions(["operation": "setEnabled", "id": item.id, "enabled": enabled], for: tab, controlID: controlID)
            guard result.contains(where: { $0.id == item.id && $0.state == (enabled ? "ENABLED" : "DISABLED") }) else {
                throw BrowserExtensionPackageError("Chromium did not confirm the extension's new state.")
            }
        }

        func uninstallExtension(_ item: BrowserExtensionRuntimeItem, for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws {
            guard !extensionOperationInProgress else { throw BrowserExtensionPackageError("Another extension operation is in progress.") }
            extensionOperationInProgress = true
            defer { extensionOperationInProgress = false }
            let result = try await requestExtensions(["operation": "uninstall", "id": item.id], for: tab, controlID: controlID)
            guard !result.contains(where: { $0.id == item.id }) else {
                throw BrowserExtensionPackageError("Chromium did not confirm the extension was removed.")
            }
            if let extensionStore, await extensionStore.isManaged(item) {
                try await extensionStore.removeUninstalled(item, installed: result)
            }
        }

        private func requestExtensions(_ parameters: [String: Any], for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws -> [BrowserExtensionRuntimeItem] {
            try await requestExtensionSnapshot(parameters, for: tab, controlID: controlID).extensions
        }

        private func requestExtensionSnapshot(_ parameters: [String: Any], for tab: AgentBrowserTabState, controlID: UUID? = nil) async throws -> ExtensionSnapshot {
            let runtime = try extensionRuntime(for: tab, controlID: controlID)
            var parameters = parameters
            if let controlID {
                parameters["lease"] = controlID.uuidString
            }
            let request = try JSONSerialization.data(withJSONObject: parameters)
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                runtime.requestBrowserExtensions?(forTab: tab.identifier, request: request) { data, error in
                    if let error {
                        continuation.resume(throwing: BrowserExtensionPackageError(error))
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: BrowserExtensionPackageError("Chromium returned no extension state."))
                    }
                }
            }
            return try JSONDecoder().decode(ExtensionSnapshot.self, from: data)
        }
    }
#endif
