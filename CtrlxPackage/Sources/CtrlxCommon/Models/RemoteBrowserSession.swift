import CtrlxNetworking
import Foundation
import Observation

/// One visible Viewer surface: at most one frame and one ordered input request.
@MainActor @Observable
public final class RemoteBrowserSession {
    public private(set) var tab: RemoteBrowserTab
    public private(set) var frame: RemoteBrowserFrame?
    public private(set) var controlID: UUID?
    public private(set) var error: String?
    public private(set) var frameError: String?
    public private(set) var isTakingControl = false
    @ObservationIgnored private let surfaceID = UUID()
    @ObservationIgnored private let send: @MainActor (BrowseBrowser) async throws -> RemoteBrowserResponse
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var inputs: [(RemoteBrowserOperation, UInt64)] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputEpoch = UUID()

    public init(tab: RemoteBrowserTab, send: @escaping @MainActor (BrowseBrowser) async throws -> RemoteBrowserResponse) {
        self.tab = tab; self.send = send
    }

    public convenience init(tab: RemoteBrowserTab, client: ViewerRelayClient) {
        self.init(tab: tab) { request in
            let result = try await client.sendCommand(request, paneId: "", timeout: 8).get()
            guard result.success, let response = result.browser else {
                throw ViewerRelayClientError.commandFailed(result.error ?? "Missing browser response")
            }
            return response
        }
    }

    private func request(_ operation: RemoteBrowserOperation, generation: UInt64? = nil) -> BrowseBrowser {
        BrowseBrowser(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surfaceID, controlID: controlID,
                      generation: generation ?? frame?.generation, operation: operation)
    }

    public func watch() async {
        stop()
        watching = true
        let current = epoch
        var first = true
        defer { if epoch == current { stop() } }
        while !Task.isCancelled, watching, epoch == current {
            let sent = request(.frame)
            do {
                let response = try await send(sent)
                try Task.checkCancellation()
                guard epoch == current, let frame = response.frame, frame.isValid else { return }
                if self.frame != frame { self.frame = frame }
                frameError = nil
                if let tab = response.tab { self.tab = tab }
                if controlID == sent.controlID, controlID != response.controlID {
                    invalidateInput()
                    controlID = response.controlID
                }
                if first, !tab.isAgentOwned, !tab.isControlled { await takeControl() }
                first = false
            } catch is CancellationError { return }
            catch { if epoch == current { frameError = error.localizedDescription } }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
    }

    public func stop() {
        watching = false
        epoch = UUID()
        releaseControl()
        frame = nil
    }

    public func takeControl() async {
        guard watching, !isTakingControl, controlID == nil else { return }
        isTakingControl = true
        defer { isTakingControl = false }
        let current = epoch
        do {
            let result = try await send(request(.takeControl))
            guard watching, epoch == current, !Task.isCancelled else {
                if let id = result.controlID { release(id) }
                return
            }
            controlID = result.controlID
            if let tab = result.tab { self.tab = tab }
            error = nil
        } catch { if epoch == current { self.error = error.localizedDescription } }
    }

    public func releaseControl() {
        invalidateInput()
        if let id = controlID { release(id) }
        controlID = nil
    }

    private func invalidateInput() {
        inputEpoch = UUID()
        inputs.removeAll()
        inputTask?.cancel()
        inputTask = nil
    }

    private func release(_ id: UUID) {
        let message = BrowseBrowser(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surfaceID,
                                    controlID: id, operation: .releaseControl)
        // Best effort on disappearance. Host also releases on disconnect/expiry.
        Task { [send] in _ = try? await send(message) }
    }

    public func dismissError() { error = nil; frameError = nil }

    public func submit(_ operation: RemoteBrowserOperation) {
        guard let frame else { return }
        submit(operation, generation: frame.generation)
    }

    public func submit(_ operation: RemoteBrowserOperation, generation: UInt64) {
        guard watching, let controlID else { return }
        if case let .pointer(new) = operation, new.kind == .move,
           let last = inputs.last, last.1 == generation, case let .pointer(old) = last.0, old.kind == .move {
            inputs[inputs.count - 1] = (operation, generation)
        } else if case let .pointer(new) = operation, new.kind == .scroll,
                  let last = inputs.last, last.1 == generation,
                  case let .pointer(old) = last.0, old.kind == .scroll, old.modifiers == new.modifiers {
            inputs[inputs.count - 1] = (.pointer(.init(.scroll, x: new.x, y: new.y, modifiers: new.modifiers,
                deltaX: max(-4096, min(4096, old.deltaX + new.deltaX)),
                deltaY: max(-4096, min(4096, old.deltaY + new.deltaY)))), generation)
        } else {
            guard inputs.count < 32 else {
                error = "Connection is too slow for more input. Control was released; no input will be replayed."
                releaseControl()
                return
            }
            inputs.append((operation, generation))
        }
        guard inputTask == nil else { return }
        let current = epoch
        let inputGeneration = inputEpoch
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.inputEpoch == inputGeneration { self.inputTask = nil } }
            while !Task.isCancelled, self.epoch == current, self.inputEpoch == inputGeneration,
                  self.controlID == controlID, !self.inputs.isEmpty {
                let (operation, generation) = self.inputs.removeFirst()
                do {
                    _ = try await self.send(self.request(operation, generation: generation))
                } catch {
                    guard !Task.isCancelled, self.epoch == current,
                          self.inputEpoch == inputGeneration, self.controlID == controlID else { return }
                    self.error = error.localizedDescription
                    self.inputs.removeAll()
                    self.releaseControl()
                    return
                }
            }
        }
    }

    public static func create(sessionName: String, client: ViewerRelayClient) async throws -> RemoteBrowserTab {
        let request = BrowseBrowser(sessionName: sessionName, surfaceID: UUID(), operation: .create)
        let result = try await client.sendCommand(request, paneId: "", timeout: 10).get()
        guard let tab = result.browser?.tab else { throw ViewerRelayClientError.commandFailed("Host did not return the new browser tab") }
        client.rememberCreatedBrowser(tab)
        _ = await client.requestSessionState()
        return tab
    }

    public static func close(tab: RemoteBrowserTab, client: ViewerRelayClient) async throws {
        let session = RemoteBrowserSession(tab: tab, client: client)
        _ = try await session.send(session.request(.close))
        _ = await client.requestSessionState()
    }
}
